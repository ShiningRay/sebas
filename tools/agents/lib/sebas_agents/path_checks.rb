# frozen_string_literal: true

module SebasAgents
  # #125：合并后 Verifier 的三类确定性检查——路径联动、安全不变量、CWE 汇总。
  #
  # 全部是纯函数：输入变更清单（path + patch）、PR 正文与 review threads，
  # 输出写入 VerificationReport。不可确定性判定的部分（覆盖率、测试正确性、
  # 未知漏洞）不在这里——本模块不承诺「证明没有漏洞」。
  #
  # 误报必须能被显式豁免且留痕：豁免以 acceptable 条目落报告，不靠改规则绕过。
  module PathChecks
    Change = Struct.new(:path, :patch, keyword_init: true)

    # workflow uses: 必须钉 40 位 sha。校验对象是 uses: 后捕获的**实际字段值**
    # （去引号、锚定整值），不是整行子串——注释里的 40 位文本骗不过校验，
    # 带引号的合法引用也能通过（CodeRabbit）。
    USES_FULL_SHA = /\A[\w.-]+\/[\w.-]+@[0-9a-f]{40}\z/
    # 只校验新增/保留行（^\+）：删除未钉引用属正常修复，不得报 blocker（CodeRabbit）。
    USES_LINE = /^\+.*?\buses:\s*(\S+)/

    # 凭据正则（近似）：输出语句与凭据词同行。token 前缀词（token_count）
    # 会误报——按卡面走「可留项复核」人工留，不走改规则。
    CREDENTIAL_LINE = /^\+.*\b(puts|log\w*|print\w*)\b.*\b(token|password|secret|api[_-]?key|private[_-]?key)/i
    # 自身的这个正则定义行不应被判为违规（测试/规则代码里的字面量）。
    # tools/tests/ 是测试套件的家：夹具里写 token 之类的字面量是常态。
    RULE_FILE_PREFIXES = %w[tools/tests/ tools/test_ tools/agents/lib/sebas_agents/path_checks.rb].freeze

    EVIDENCE_SOURCES_TOUCH = /^\+.*SOURCES/
    # git push 的长/短 force 参数都要拦（-f 须带词边界，避免误伤 -file 类参数）。
    FORCE_PUSH_LINE = /^\+.*\bgit\s+push\b.*(\s--force\b|\s--force-with-lease\b|\s-f\b)/
    # 分支保护仅拦显式写方法（PUT/POST/DELETE）；读取保护配置不是写。
    # 目标路径与方法分开判定，不依赖两者顺序；--method 支持空格与等号两种形式。
    BRANCH_PROTECTION_PATH = /branch(es)?[\w\/.-]*protection/
    WRITE_METHOD_FLAG = /(-X\s+(PUT|POST|DELETE)|--method[= ](PUT|POST|DELETE))/

    NO_BEHAVIOR_CHANGE = /无行为变更|no\s+behavior\s+change/i
    SECURITY_BOUNDARY = /安全边界|security\s+boundary/i
    CWE_ID = /CWE-\d+/

    module_function

    # A. 路径联动 + B. 安全不变量 + C. CWE，全部落进 report。
    def check(changes:, body:, threads:, report:)
      changes = Array(changes).map { |c| c.is_a?(Hash) ? Change.new(path: c["filename"] || c[:path], patch: c["patch"]) : c }
      # patch 缺失的文件无法扫描——明确拒绝核验，不按空改动放行（CodeRabbit）。
      changes.reject { |c| c.patch }.each do |c|
        report.blocker("变更文件 #{c.path} 无 patch 内容，无法核验（fail-closed）")
      end
      changes = changes.select(&:patch)
      path_linkage(changes, body, report)
      security_invariants(changes, report)
      unresolved_cwe(Array(threads), report)
      report
    end

    # A. 路径联动（规则写死；误报走显式豁免并留痕）。
    def path_linkage(changes, body, report)
      changes = Array(changes).map { |c| c.is_a?(Hash) ? Change.new(path: c["filename"] || c[:path], patch: c["patch"]) : c }
      paths = changes.map(&:path)

      src_changes = changes.select { |c| c.path.start_with?("src/") && c.path.end_with?(".cr") }
      spec_changed = paths.any? { |p| p.start_with?("spec/") }
      docs_changed = paths.any? { |p| p.start_with?("docs/") }
      workflow_changed = paths.any? { |p| p.start_with?(".github/workflows/") }
      tools_changes = changes.select { |c| c.path.start_with?("tools/") && c.path.end_with?(".rb") }
      # 只认 tools/test_*.rb 与 tools/tests/**/test_*.rb 两种约定；
      # test_ 前缀的 Markdown 等非 Ruby 文件不算测试改动。
      tools_tests_changed = paths.any? { |p| p.match?(%r{\Atools/(?:tests/(?:[^/]+/)*)?test_[^/]*\.rb\z}) }
      declares_no_behavior = NO_BEHAVIOR_CHANGE.match?(body.to_s)
      declares_security = SECURITY_BOUNDARY.match?(body.to_s)

      unless src_changes.empty?
        # 例外：改动仅空白或 # 注释行时可豁免（diff 级判定），豁免以 acceptable 留痕。
        substantive = src_changes.reject { |c| blank_or_comment_only?(c.patch) }
        if substantive.empty?
          report.acceptable("src/ 改动全部为空白/注释（豁免 spec 联动）：#{paths_list(src_changes)}")
        elsif !spec_changed
          report.blocker("src/ 有实质改动但 spec/ 无任何变更：#{paths_list(src_changes)}")
        end

        if substantive.any? && !docs_changed && !declares_no_behavior
          report.must_fix("src/ 有实质改动但 docs/ 无变更且 PR 正文未声明「无行为变更」")
        end
      end

      if workflow_changed && !declares_security
        report.must_fix(".github/workflows/ 有改动但 PR 正文缺「安全边界」说明")
      end

      substantive_tools = tools_changes.reject do |c|
        File.basename(c.path).start_with?("test_") || blank_or_comment_only?(c.patch)
      end
      if substantive_tools.any? && !tools_tests_changed
        report.blocker("tools/ 有实质改动但无 test_*.rb 测试变更：#{paths_list(substantive_tools)}")
      end
    end

    # B. 安全不变量（可确定性判定的四项）。
    def security_invariants(changes, report)
      changes = Array(changes).map { |c| c.is_a?(Hash) ? Change.new(path: c["filename"] || c[:path], patch: c["patch"]) : c }

      changes.select { |c| c.path.start_with?(".github/workflows/") }.each do |change|
        (change.patch || "").each_line do |line|
          if (uses = line.match(USES_LINE))
            ref = uses[1].gsub(/\A["']|["']\z/, "")
            unless USES_FULL_SHA.match?(ref)
              report.blocker("workflow #{change.path} 的 uses 未钉 SHA：#{ref}（必须 <owner>/<repo>@<40位sha>）")
            end
          end
          next unless FORCE_PUSH_LINE.match?(line) ||
            (BRANCH_PROTECTION_PATH.match?(line) && WRITE_METHOD_FLAG.match?(line))

          report.blocker("workflow #{change.path} 疑似改写 push 保护或分支保护：#{line.strip[0, 120]}")
        end
      end

      changes.each do |change|
        next if RULE_FILE_PREFIXES.any? { |prefix| change.path.start_with?(prefix) }

        (change.patch || "").each_line do |line|
          if CREDENTIAL_LINE.match?(line)
            report.must_fix("疑似凭据进入输出语句（正则近似，误报可走可留复核）：#{change.path}：#{line.strip[0, 120]}")
          end
        end
      end

      evidence_file = changes.find { |c| c.path.end_with?("policy/evidence.rb") }
      if evidence_file && (evidence_file.patch || "").match?(EVIDENCE_SOURCES_TOUCH)
        report.blocker("policy/evidence.rb 触碰 SOURCES（Evidence 授权段位变更须人工审）")
      end
    end

    # C. CodeRabbit CWE 意见汇总：已 resolve 的计入已处理；未 resolve 的判 blocker。
    # 不自行判断 CWE 意见是否误报——那是人的事。
    def unresolved_cwe(threads, report)
      hits = Array(threads).reject { |t| t["isResolved"] == true }.select do |t|
        Array(t["comments"]).any? { |c| CWE_ID.match?(c["body"].to_s) }
      end
      return if hits.empty?

      summary = hits.filter_map do |t|
        first = Array(t["comments"]).first
        body = first.is_a?(Hash) ? first["body"].to_s : first.to_s
        ids = body.scan(CWE_ID).uniq.join("、")
        "#{ids || "CWE-?"}（#{t["path"] rescue "?"}）"
      end
      report.blocker("存在 #{hits.length} 条未 resolve 的 CWE 安全意见：#{summary.join("；")}")
    end

    # diff 级豁免判定：新增/删除行剔除空白与 # 注释后无实质内容。
    def blank_or_comment_only?(patch)
      return false if patch.nil?

      lines = patch.each_line.reject { |l| l.start_with?("+++", "---") }
      body_lines = lines.select { |l| l.start_with?("+", "-") }
      return false if body_lines.empty?

      substantive = body_lines.map { |l| l.delete_prefix("+").delete_prefix("-").strip }
        .reject { |l| l.empty? || l.start_with?("#") }
      substantive.empty?
    end

    def paths_list(changes)
      changes.map(&:path).uniq.join("、")
    end
  end
end
