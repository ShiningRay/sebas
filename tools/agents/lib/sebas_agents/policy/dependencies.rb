# frozen_string_literal: true

module SebasAgents
  module Policy
    # 依赖判定：WP「依赖」字段为权威（此处体现在 Automation.depends_on 与原生 blocked_by 的一致性核对）。
    module Dependencies
      KINDS = %w[work_package tracking manual].freeze
      ARRAY_FIELDS = %w[depends_on external].freeze

      module_function

      # 解析并校验 Automation 块；返回 nil 表示非工作包或未登记。
      def automation_for(issue)
        block = JsonBlock.one(issue.body, "automation", subject: "issue ##{issue.number}")
        return nil unless block

        raise InvalidPlan, "##{issue.number} 的 automation 必须是对象" unless block.is_a?(Hash)
        unless KINDS.include?(block["kind"])
          raise InvalidPlan, "##{issue.number} 的 automation.kind 非法：#{block["kind"].inspect}"
        end
        order = block["order"]
        unless order.is_a?(Array) && order.all? { |part| part.is_a?(Integer) && part >= 0 }
          raise InvalidPlan, "##{issue.number} 的 automation.order 必须是非负整数数组"
        end
        ARRAY_FIELDS.each do |field|
          raise InvalidPlan, "##{issue.number} 的 automation.#{field} 必须显式写出数组" unless block[field].is_a?(Array)
        end

        block
      end

      def evaluate(issue, snapshot)
        automation = issue.automation
        return Model::Evaluation.new(status: "invalid", reasons: ["##{issue.number} 缺 Automation 块"]) unless automation

        status = "ready"
        reasons = []

        declared = automation["depends_on"].map(&:to_s)
        declared_externals = declared.grep(/\Aexternal:/)
        Array(automation["external"]).map { |item| "external:#{item.to_s.delete_prefix("external:")}" }.each do |key|
          reasons << "##{issue.number} 的 #{key} 未进入 depends_on" unless declared_externals.include?(key)
        end

        expected = declared.grep(/\A\d+\z/).map(&:to_i).sort
        if expected != issue.blocked_by.sort
          reasons << "##{issue.number} 的 GitHub blocked_by #{issue.blocked_by.sort.inspect} 与 Automation #{expected.inspect} 不一致"
        end

        # 卡面「依赖」字段与 Automation 的三方对账（#108 问题 2）。
        # 前置已关闭时依赖判定会 vacuous 通过；此处独立比对声明口径，避免分叉被静默放过。
        # prose 为 nil 表示卡面无依赖节，无从对账；空数组表示明确声明「无前置」。
        prose = prose_dependencies(issue.body)
        if prose
          undeclared = prose - expected
          reasons << "##{issue.number} 正文依赖字段提到 #{undeclared.inspect}，但 Automation depends_on 未声明" unless undeclared.empty?
          unmentioned = expected - prose
          reasons << "##{issue.number} 的 Automation depends_on #{unmentioned.inspect} 未出现在正文依赖字段" unless unmentioned.empty?
        end
        status = "invalid" unless reasons.empty?

        declared.each do |dependency|
          result = evaluate_one(dependency, issue, snapshot)
          status = "invalid" if result.invalid?
          status = "blocked" if result.status == "blocked" && status == "ready"
          reasons.concat(result.reasons)
        end

        Model::Evaluation.new(status: status, reasons: reasons)
      rescue InvalidPlan => e
        Model::Evaluation.new(status: "invalid", reasons: [e.message])
      end

      # 从卡面「前置依赖」/「依赖」节抽取显式 #N 依赖引用。
      # 返回 nil 表示卡面没有依赖节（无从对账，不校验）；
      # 返回数组（可为空）表示存在依赖节，空数组即声明「无前置」。
      #
      # 只认依赖句里的编号：卡面还会写「见 #35 开工条件」这类引用说明，
      # 全局扫 #N 会把说明误判成依赖。因此逐行处理，且只剥掉「引用说明」本身——
      # 不能整行跳过，否则同一行里的真实依赖（如「WP1（#3）完成；另见 #35」）会丢失。
      DEPENDENCY_HEADING = /^#+\s*(前置依赖|依赖)\s*$/
      # 括号内以引用词开头的补充说明，例如「（见 #35 开工条件）」。
      REFERENCE_PAREN = /[（(]\s*(?:见|参见|详见)[^）)]*[）)]/
      # 行内引用短语，例如「另见 #35 开工条件」「参见 #7」。
      REFERENCE_INLINE = /(?:另?见|参见|详见)\s*#\d+[^；;。\n]*/

      def prose_dependencies(body)
        # 卡面正文来自 GitHub API（UTF-8），但离线快照或本地记录可能是其它编码；
        # 强制按 UTF-8 归一，避免中文正则遇到非 UTF-8 串直接抛 Encoding::CompatibilityError。
        text = body.to_s.dup.force_encoding(Encoding::UTF_8)
        text = text.scrub unless text.valid_encoding?
        lines = text.lines
        start = lines.index { |line| line.match?(DEPENDENCY_HEADING) }
        return nil unless start

        section = []
        lines[(start + 1)..].to_a.each do |line|
          break if line.match?(/^#+\s+\S/) && !line.match?(DEPENDENCY_HEADING)

          section << line
        end

        numbers = []
        section.each do |line|
          stripped = line.strip
          next if stripped.empty?

          # 只剥引用说明，保留承载真实依赖的括号（如「WP1（#3，开工条件已满足）」）。
          main = stripped.gsub(REFERENCE_PAREN, "").gsub(REFERENCE_INLINE, "")
          numbers.concat(main.scan(/#(\d+)/).flatten.map(&:to_i))
        end
        numbers.uniq.sort
      end

      def evaluate_one(dependency, issue, snapshot)
        case dependency
        when /\A(\d+)\z/
          evaluate_issue_dependency(Regexp.last_match(1).to_i, issue, snapshot)
        when /\Agate:(.+)\z/
          Evidence.evaluate_gate(snapshot.gates[dependency], Regexp.last_match(1), snapshot)
        when /\Aexternal:(.+)\z/
          Evidence.evaluate_external(snapshot.externals[dependency], Regexp.last_match(1), snapshot)
        else
          Model::Evaluation.new(status: "invalid", reasons: ["##{issue.number} 的依赖格式非法：#{dependency.inspect}"])
        end
      end

      def evaluate_issue_dependency(number, issue, snapshot)
        target = snapshot.issue(number)
        # 快照缺前置是“未知/未满足”，不是元数据冲突（§2.3 最后一句）。
        return Model::Evaluation.new(status: "blocked", reasons: ["前置 ##{number} 不在快照内"]) unless target

        unless target.completed?
          detail = target.closed? ? "state_reason=#{target.state_reason.inspect}" : "仍 open"
          return Model::Evaluation.new(status: "blocked", reasons: ["前置 ##{number} #{detail}"])
        end

        # 已 completed 的 issue 若仍带认领标签，说明状态迁移未收口。
        if target.label?(Model::IN_PROGRESS_LABEL)
          return Model::Evaluation.new(status: "invalid",
            reasons: ["前置 ##{number} 已关闭但仍带 #{Model::IN_PROGRESS_LABEL}"])
        end

        block = Evidence.from_issue(target)
        Evidence.evaluate_issue(block, number, snapshot)
      rescue InvalidPlan => e
        Model::Evaluation.new(status: "invalid", reasons: [e.message])
      end

      # 整批候选：引用存在、无环、计划顺序唯一。
      # 使用已注入 Automation 的候选集，避免读到快照里未解析的副本。
      def validate_graph(issues, snapshot)
        problems = []
        by_number = issues.to_h { |issue| [issue.number, issue] }
        known = (snapshot.issues.map(&:number) + by_number.keys).uniq

        issues.each do |issue|
          issue.automation["depends_on"].map(&:to_s).grep(/\A\d+\z/).map(&:to_i).each do |dependency|
            problems << [issue.number, "引用了快照外的前置 ##{dependency}"] unless known.include?(dependency)
          end
        end

        issues.group_by { |issue| issue.automation["order"] }
          .select { |_order, items| items.length > 1 }
          .each do |order, items|
            problems << [items.first.number,
              "计划顺序 #{order.inspect} 重复：#{items.map(&:number).join("、")}"]
          end

        cycles(by_number).each do |cycle|
          problems << [cycle.first, "依赖成环：#{cycle.join(" → ")}"]
        end

        problems
      end

      def cycles(by_number)
        state = Hash.new(:unvisited)
        stack = []
        found = []

        visit = lambda do |number|
          case state[number]
          when :done then return
          when :visiting
            start = stack.index(number) || 0
            found << (stack[start..] + [number])
            return
          end

          state[number] = :visiting
          stack.push(number)
          issue = by_number[number]
          issue&.automation&.fetch("depends_on", [])&.map(&:to_s)&.grep(/\A\d+\z/)&.each do |dependency|
            visit.call(dependency.to_i) if by_number.key?(dependency.to_i)
          end
          stack.pop
          state[number] = :done
        end

        by_number.each_key { |number| visit.call(number) }
        found.uniq
      end
    end
  end
end
