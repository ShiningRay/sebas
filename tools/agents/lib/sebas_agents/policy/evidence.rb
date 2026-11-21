# frozen_string_literal: true

module SebasAgents
  module Policy
    # 可机读证据契约：docs/design/process/implementer-loop.md §2.4。
    # 三种主体：issue:<n>（工作包）、gate:<名称>（期门禁）、external:<E.1>（外部依赖）。
    #
    # 分级规则：
    #   - 缺记录、前置未完成        → blocked（未满足，等条件）
    #   - 结构非法、对象不匹配、
    #     登记人不可信、状态字段错   → invalid（元数据冲突，fail-closed 交 Maintainer）
    #
    # 登记人两种来源，均须白名单佐证，JSON 里的 source 字符串本身不是凭据：
    #   - "maintainer"：source_ref 作者属 .github/agents.yml 的 maintainers（人类）
    #   - "workflow"  ：source_ref 作者属 .github/agents.yml 的 trusted_bots（自动化身份）
    module Evidence
      SCHEMA = 1
      SOURCE = "maintainer"
      WORKFLOW_SOURCE = "workflow"
      SOURCES = [SOURCE, WORKFLOW_SOURCE].freeze

      module_function

      def from_issue(issue)
        block = JsonBlock.one(issue.body, "evidence", subject: "issue ##{issue.number}")
        return nil unless block

        validate_shape(block, subject: "issue ##{issue.number}")
      end

      def validate_shape(block, subject:)
        raise InvalidPlan, "#{subject} 的 evidence 必须是对象" unless block.is_a?(Hash)
        raise InvalidPlan, "#{subject} 的 evidence.schema 必须为 #{SCHEMA}" unless block["schema"] == SCHEMA
        raise InvalidPlan, "#{subject} 的 evidence 缺 subject" unless block["subject"].is_a?(String)
        raise InvalidPlan, "#{subject} 的 evidence 缺 status" unless block["status"].is_a?(String)
        raise InvalidPlan, "#{subject} 的 evidence 缺 source" unless block["source"].is_a?(String)
        raise InvalidPlan, "#{subject} 的 evidence 缺 source_ref" unless block["source_ref"].is_a?(String)

        block
      end

      # source_ref 的实际作者必须在对应白名单内；JSON 的 source 字符串不算凭据。
      # "maintainer" 比对 maintainers（人类），"workflow" 比对 trusted_bots（自动化身份）。
      def trusted?(block, snapshot)
        source = block["source"]
        return false unless SOURCES.include?(source)

        author = snapshot.source_authors[block["source_ref"].to_s]
        return false if author.nil?

        if source == WORKFLOW_SOURCE
          snapshot.trusted_bots.include?(author)
        else
          snapshot.maintainers.include?(author)
        end
      end

      def evaluate_issue(block, number, snapshot)
        subject = "issue:#{number}"
        return blocked(subject) unless block

        return mismatch(subject, block) unless block["subject"] == subject
        return unauthorized(subject) unless trusted?(block, snapshot)

        # §2.4：状态不符、未进 main、必需项未实测均算“未满足”。
        reasons = []
        reasons << "#{subject} 的 status 必须为 accepted" unless block["status"] == "accepted"
        reasons << "#{subject} 的 ready 必须为 null" unless block["ready"].nil?
        reasons << "#{subject} 缺 merge_commit" if block["merge_commit"].to_s.empty?
        reasons << "#{subject} 的 merge_commit 未确认进入 main" unless block["merged_into_main"] == true
        untested = Array(block["untested"])
        reasons << "#{subject} 仍有未实测必需项：#{untested.join("、")}" unless untested.empty?
        return blocked_with(subject, reasons) unless reasons.empty?

        ready(subject)
      end

      def evaluate_gate(block, name, snapshot)
        subject = "gate:#{name}"
        return blocked(subject) unless block

        return mismatch(subject, block) unless block["subject"] == subject
        return unauthorized(subject) unless trusted?(block, snapshot)

        reasons = []
        reasons << "#{subject} 的 status 必须为 accepted" unless block["status"] == "accepted"
        reasons << "#{subject} 的 ready 必须为 null" unless block["ready"].nil?
        reasons << "#{subject} 的 gate_status 必须为 go" unless block["gate_status"].to_s.downcase == "go"
        reasons << "#{subject} 缺已合入的 evidence_path" if block["evidence_path"].to_s.empty?
        return blocked_with(subject, reasons) unless reasons.empty?

        ready(subject)
      end

      def evaluate_external(block, name, snapshot)
        subject = "external:#{name}"
        return blocked(subject) unless block

        return mismatch(subject, block) unless block["subject"] == subject
        return unauthorized(subject) unless trusted?(block, snapshot)

        reasons = []
        reasons << "#{subject} 的 status 必须为 ready" unless block["status"] == "ready"
        reasons << "#{subject} 的 ready 必须为 true" unless block["ready"] == true
        return blocked_with(subject, reasons) unless reasons.empty?

        ready(subject)
      end

      def ready(subject)
        Model::Evaluation.new(status: "ready", reasons: ["#{subject} 已满足"])
      end

      def blocked(subject)
        Model::Evaluation.new(status: "blocked", reasons: ["#{subject} 无 Evidence 记录"])
      end

      def blocked_with(subject, reasons)
        Model::Evaluation.new(status: "blocked", reasons: reasons)
      end

      def invalid(subject, reasons)
        Model::Evaluation.new(status: "invalid", reasons: reasons.empty? ? ["#{subject} 证据非法"] : reasons)
      end

      def mismatch(subject, block)
        invalid(subject, ["#{subject} 的 Evidence subject 为 #{block["subject"].inspect}"])
      end

      def unauthorized(subject)
        invalid(subject, ["#{subject} 的 Evidence 未由 Maintainer 或受信 bot 登记"])
      end
    end
  end
end
