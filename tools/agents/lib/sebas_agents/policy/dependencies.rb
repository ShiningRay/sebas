# frozen_string_literal: true

module SebasAgents
  module Policy
    # 依赖判定：WP「依赖」字段为权威（此处体现在 Automation.depends_on 与原生 blocked_by 的一致性核对）。
    module Dependencies
      KINDS = %w[work_package tracking manual design].freeze
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

        # scope（M4x-Parallel-WP2，#220；Proposal §6.1）：可选字段，校验并归一
        # 尾部 `/`——非法值上抛（调度预算声明非法不能静默忽略），nil 保持 nil。
        block["scope"] = Scope.normalize(block["scope"], issue_number: issue.number) if block.key?("scope")

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
        elsif automation["kind"] == "work_package"
          # 工作包写了依赖节但标题不合规（如「依赖关系」）时，prose 为 nil，
          # 上面整段核对被跳过——看着绿灯，实际没校验。必须显式报错，不能静默放过。
          variants = mismatched_dependency_headings(issue.body)
          unless variants.empty?
            reasons << "##{issue.number} 的依赖节标题不是「依赖」或「前置依赖」：" \
              "#{variants.map(&:inspect).join("、")}；正文依赖核对因此被跳过"
          end
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
      #
      # 与变体检测共用同一套 ATX 标题解析，避免两边对「什么算标题」判断不一致：
      # 缩进的 `  ## 依赖` 和带闭合标记的 `## 依赖 ##` 都是合法依赖节。
      DEPENDENCY_HEADING_TITLES = %w[依赖 前置依赖].freeze
      # 括号内以引用词开头的补充说明，例如「（见 #35 开工条件）」。
      REFERENCE_PAREN = /[（(]\s*(?:见|参见|详见)[^）)]*[）)]/
      # 行内引用短语，例如「另见 #35 开工条件」「参见 #7」。
      REFERENCE_INLINE = /(?:另?见|参见|详见)\s*#\d+[^；;。\n]*/

      def prose_dependencies(body)
        text = normalize_body(body)
        lines = text.lines
        fenced = fenced_line_indexes(lines)
        start = lines.each_index.find do |index|
          next if fenced.include?(index)

          level, title = heading_at(lines, index)
          level && DEPENDENCY_HEADING_TITLES.include?(title)
        end
        return nil unless start

        level, = heading_at(lines, start)
        section = []
        ((start + 1)...lines.length).each do |index|
          next if fenced.include?(index)

          next_level, = heading_at(lines, index)
          break if next_level && next_level <= level

          section << lines[index]
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

      # 代码围栏内的行下标（含围栏标记行本身）。
      #
      # 按 CommonMark 判定，三处不能简化：
      #   1. 闭合围栏必须同字符（` 与 ~ 不互通）、长度 ≥ 开启长度；
      #   2. 闭合行只能有空白或闭合标记，带 info string 的不是闭合；
      #   3. ```x``` 这类单行是行内代码跨度，不是围栏，不能吞掉后续内容。
      def fenced_line_indexes(lines)
        indexes = []
        in_fence = false
        fence_char = nil
        fence_length = 0

        lines.each_with_index do |line, index|
          if in_fence
            indexes << index
            if fence_closes?(line, fence_char, fence_length)
              in_fence = false
              fence_char = nil
              fence_length = 0
            end
            next
          end

          opening = fence_opening(line)
          next unless opening

          indexes << index
          in_fence = true
          fence_char = opening[0]
          fence_length = opening[1]
        end
        indexes
      end

      # 返回 [字符, 长度]；不是围栏开启行返回 nil。
      # 反引号围栏的 info string 里不能再出现反引号（否则是行内代码跨度）。
      def fence_opening(line)
        stripped = line.sub(/\A {0,3}/, "")
        run = stripped[/\A(`{3,}|~{3,})/, 1]
        return nil unless run

        info = stripped[run.length..].to_s
        return nil if run.start_with?("`") && info.include?("`")

        [run[0], run.length]
      end

      # 闭合围栏只能有空白或若干个同字符标记，且长度不少于开启长度。
      def fence_closes?(line, char, length)
        !line.match(/\A {0,3}(#{Regexp.escape(char)}{#{length},})[ \t]*\n?\z/).nil?
      end

      # 依赖节标题写法不合规的变体，例如「依赖关系」「外部依赖」「依赖顺序」。
      # 这些标题会让 prose_dependencies 返回 nil，正文核对被整段跳过而不报错。
      # 仅在整篇没有合规依赖节时才有意义（调用方已确认 prose 为 nil）。
      #
      # 三个收紧条件，缺一都会误报：
      #   1. `#` 后必须有空白——ATX 标题的规则，`#3 的依赖` 是正文引用而非标题。
      #   2. 只认「依赖」开头或结尾的短标题，且不含冒号——带冒号的论述性标题
      #      （如「问题 2：依赖口径校验…」）不是依赖节。
      #   3. 跳过代码围栏内的行——示例里的标题是内容，不是章节。
      VARIANT_HEADING = /\A(?:前置)?依赖[^：:]{0,10}\z|\A[^：:]{0,10}(?:前置)?依赖\z/
      EXACT_HEADING = /\A(?:前置)?依赖\z/
      # ATX 标题：≤3 个前导空格 + 1–6 个 # + 空白 + 文字，可带闭合标记。
      # 空标题（如裸 `##`）也是合法 ATX，按 CommonMark 同样终止上一节。
      ATX_HEADING = %r{\A {0,3}(\#{1,6})(?:\s+(.*?))?\s*\z}
      # 闭合标记：末尾的空格 + 若干 #（CommonMark 允许）。
      CLOSING_HASHES = /\s+#+\s*\z/

      # 解析标题行，返回 [level, title]，非标题返回 nil。空标题的 title 为 ""。
      # title 保留尾部 #N 原样——引用检查需要看到它。
      def heading_at(lines, index)
        match = lines[index].to_s.match(ATX_HEADING)
        return nil unless match

        [match[1].length, match[2].to_s.sub(CLOSING_HASHES, "").strip]
      end

      # 标题去掉尾部 issue 引用后的文字，用于分类。
      # 一次剥掉整串引用（「外部依赖 #3 #5」→「外部依赖」），
      # 并吃掉引用之间的分隔符「、，,」——否则会残留「外部依赖 #3、」，
      # 既不匹配变体规则也过不了精确标题，引用被静默忽略。
      def heading_label(title)
        rest = title
        loop do
          stripped = rest.sub(/\s*(?:[、，,]\s*)?#{ISSUE_REFERENCE.source}\s*\z/, "")
          break if stripped == rest

          rest = stripped
        end
        rest.strip
      end

      def mismatched_dependency_headings(body)
        lines = normalize_body(body).lines
        fenced = fenced_line_indexes(lines)
        variants = []

        lines.each_index do |index|
          next if fenced.include?(index)

          level, title = heading_at(lines, index)
          next unless level

          label = heading_label(title)
          # 精确标题只有在不带尾部引用时才是合规依赖节；带了引用就成了变体。
          next if label.match?(EXACT_HEADING) && label == title
          next unless label.match?(EXACT_HEADING) || label.match?(VARIANT_HEADING)
          next unless heading_or_section_mentions_issue?(lines, index, level, title)

          variants << title
        end
        variants.uniq
      end

      # 依赖声明出现在标题行本身（如「## 依赖关系 #3」）也算——否则这唯一的
      # 引用会被整段忽略，工作包静默通过。
      def heading_or_section_mentions_issue?(lines, index, level, title)
        return true if title.match?(ISSUE_REFERENCE)

        section_mentions_issue?(lines, index, level)
      end

      # 从第 index 行的标题开始，取同级与更低级的行，判断是否出现 #N 引用。
      # 只认真正的 issue 引用：「E.1#1」这类外部编号紧跟字母数字或点，不算。
      # 代码围栏内的行跳过——示例里的 #3 不是依赖。
      ISSUE_REFERENCE = /(?<![A-Za-z0-9.#])#\d+/

      def section_mentions_issue?(lines, index, level)
        fenced = fenced_line_indexes(lines)

        ((index + 1)...lines.length).each do |offset|
          next if fenced.include?(offset)

          next_level, = heading_at(lines, offset)
          break if next_level && next_level <= level
          return true if lines[offset].match?(ISSUE_REFERENCE)
        end
        false
      end

      def normalize_body(body)
        # 卡面正文来自 GitHub API（UTF-8），但离线快照或本地记录可能是其它编码。
        # 行尾统一为 LF：CRLF 会让围栏闭合正则与节末判定失配（CommonMark 两者都接受）。
        text = body.to_s.dup.force_encoding(Encoding::UTF_8)
        text = text.scrub unless text.valid_encoding?
        text.gsub("\r\n", "\n").gsub("\r", "\n")
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

        # 已 completed 的 issue 若仍是执行中 status，说明状态迁移未收口。
        if target.working?
          return Model::Evaluation.new(status: "invalid",
            reasons: ["前置 ##{number} 已关闭但仍为 status=#{target.status}"])
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
