# frozen_string_literal: true

require "json"
require "open3"
require "shellwords"

module SebasAgents
  # Verifier：只读核验。全部方法只读文件、只跑只读命令，不写仓库。
  module Verifier
    # 文档行号锚：当前有效文档不允许，历史存档记 WARN。
    LINE_ANCHOR = /(design\.md|development-plan\.md)(?:\s*(?::|：)\s*|\s+(?=L\d))(L?\d+(?:\s*[-–~]\s*\d+)?)/
    ARCHIVE_DIRS = ["docs/design/review/", "docs/design/research/"].freeze

    module_function

    # 核验文档：行号锚、估算加总、断链。返回 VerificationReport。
    def verify_docs(paths, root: Dir.pwd, max_lines: 400)
      report = VerificationReport.new
      paths.each do |path|
        full = File.expand_path(path, root)
        unless File.exist?(full)
          report.blocker("缺失文件：#{relative(full, root)}")
          next
        end

        text = File.read(full, encoding: "UTF-8")
        relative_path = relative(full, root)
        line_count = text.lines.length
        if line_count > max_lines
          # evidence 是可复跑命令（#124 终验 checker 重执行判定修复）；
          # 路径用相对 root 的形式，checker 在 root 下执行。
          report.must_fix("#{relative_path} 共 #{line_count} 行，超过 #{max_lines} 行上限",
            evidence: RERUN_LINE_COUNT % [max_lines, Shellwords.escape(relative_path)])
        end

        anchors = text.scan(LINE_ANCHOR).map { |match| match.join }
        next if anchors.empty?

        level = ARCHIVE_DIRS.any? { |dir| relative_path.start_with?(dir) } ? :acceptable : :must_fix
        anchors.tally.each do |anchor, count|
          report.public_send(level, "#{relative_path} 含行号锚 #{anchor.inspect}（#{count} 处）",
            evidence: level == :must_fix ? RERUN_DOCS_CHECK % Shellwords.escape(relative_path) : nil)
        end
      end
      report
    end

    # 终验可复跑命令模板：checker 在仓库根（root）下执行。
# 路径必须 Shellwords.escape：checker 用 Shellwords.split 解析，
# 含空格/引号的路径不转义会被拆错甚至解析失败（CodeRabbit）。
    RERUN_LINE_COUNT = "ruby -e 'exit(File.readlines(ARGV.fetch(0), encoding: \"UTF-8\").length <= %d ? 0 : 1)' %s"
    RERUN_DOCS_CHECK = "ruby tools/sebas-process verify docs %s"

    # 核验代码锚点：docs 声称的 file:line 片段必须与源码一致。
    # anchors 形如 [{"file" => "src/x.cr", "line" => 12, "content" => "..."}]
    # content 缺失或行号越界都算核验不成立，不许静默通过。
    def verify_code_anchors(anchors, root: Dir.pwd)
      report = VerificationReport.new
      unless anchors.is_a?(Array)
        report.blocker("anchors 必须是数组")
        return report
      end

      anchors.each_with_index do |anchor, index|
        label = anchor.is_a?(Hash) ? "#{anchor["file"]}:#{anchor["line"]}" : "第 #{index + 1} 项"
        unless anchor.is_a?(Hash) && anchor["file"].is_a?(String)
          report.blocker("#{label} 缺 file")
          next
        end

        line = anchor["line"]
        unless line.is_a?(Integer) && line.positive?
          report.blocker("#{label} 的 line 必须是正整数，收到 #{line.inspect}")
          next
        end

        content = anchor["content"]
        if content.nil? || content.to_s.empty?
          report.blocker("#{label} 缺 content，无法核验")
          next
        end

        path = File.expand_path(anchor["file"], root)
        unless File.exist?(path)
          report.blocker("锚点文件不存在：#{anchor["file"]}")
          next
        end

        lines = File.readlines(path, encoding: "UTF-8")
        if line > lines.length
          report.blocker("#{label} 行号越界：文件只有 #{lines.length} 行")
          next
        end

        actual = lines[line - 1].to_s
        if actual.include?(content)
          report.ok("#{label} 一致")
        else
          # 此条 evidence 留空：复跑需要「重新 extract + verify」两段命令，
          # 不满足终验 checker 的单命令白名单口径；修复后由新 CI 产物承载
          # 修复结果（该条目在新产物中消失），终验读新产物即可收口。
          report.must_fix("#{label} 实际内容与文档声称不符")
        end
      end
      report
    end

    # 只读请求的最终校验：PR 状态、关联 issue、CI 与合并 commit。
    #
    # 两种模式（#107）：
    #   pre: false（默认，合并后核验）：要求 PR 已合并、issue 已 completed，
    #            并核对 merge commit 进入 main。这是收口时的完整性核验。
    #   pre: true（合并前自检）：合并与关闭在结构上还不可能成立，故跳过这两条，
    #            只核验可提前判定的项——关联 issue、CI 全绿、无未完成检查、
    #            Evidence 已 accepted、review thread 全部解决。
    #            不能整段复用合并后口径：那会让「合并前必须退出码 0」永远失败。
    def verify_merge(pr_number, issue_number, snapshot, expected_head: nil, pre: false)
      report = VerificationReport.new
      pr = snapshot.pull_request(pr_number)
      unless pr
        report.blocker("PR ##{pr_number} 不在快照内")
        return report
      end
      if pre
        report.blocker("PR ##{pr_number} 已关闭但未合并") if !pr.open? && !pr.merged?
      elsif !pr.merged?
        report.blocker("PR ##{pr_number} 未合并")
      end
      report.blocker("PR ##{pr_number} 未关联 issue ##{issue_number}") unless pr.closing_issues.include?(issue_number)
      if pr.failing_checks.any?
        report.blocker("PR ##{pr_number} 存在失败检查：#{pr.failing_checks.map { |c| c["name"] }.join("、")}")
      end
      if pr.pending_checks.any?
        # 合并前自检里，CI 未完成不能算可放行。
        pre ? report.blocker("PR ##{pr_number} 仍有未完成的检查") : report.must_fix("PR ##{pr_number} 仍有未完成的检查")
      end
      # 「全绿」不能由「没有失败记录」推出：checks 为空说明快照没取到 CI 结果，
      # 此时放行等于把「没看见」当成「通过」。
      if pre && pr.checks.empty?
        report.blocker("PR ##{pr_number} 没有任何 CI 检查记录，无法确认全绿")
      end
      if expected_head && pr.head_sha != expected_head
        report.must_fix("PR ##{pr_number} head #{pr.head_sha} 与记录的 #{expected_head} 不符")
      end

      issue = snapshot.issue(issue_number)
      if issue.nil?
        report.blocker("issue ##{issue_number} 不在快照内")
      elsif pre
        report.blocker("issue ##{issue_number} 已关闭，不能再作为合并前自检对象") unless issue.open?

        # 合并前门禁必须覆盖 Evidence 与 review thread，否则可带着未验收结论合并。
        if pr.unresolved_threads.any?
          report.blocker("PR ##{pr_number} 仍有 #{pr.unresolved_threads.length} 条未解决 review thread")
        end
        evidence = Policy::Evidence.from_issue(issue)
        if evidence.nil?
          report.blocker("issue ##{issue_number} 缺 Evidence 块")
        elsif !Policy::Evidence.trusted?(evidence, snapshot)
          # 只查 status 字段不够：issue 正文可被任意有写权限者编辑，
          # 必须与依赖判定同口径校验登记人身份与评论内容。
          report.blocker("issue ##{issue_number} 的 Evidence 未由 Maintainer 或受信 bot 登记")
        else
          # 合并前不可能有 merged_into_main，只判 accepted + 无未实测。
          # 反过来：若已声称 true，说明证据已被篡改，必须阻断而非放行。
          if evidence["merged_into_main"] == true
            report.blocker("issue ##{issue_number} 的 Evidence 声称 merged_into_main=true，但 PR ##{pr_number} 未合并")
          end
          unless evidence["status"] == "accepted"
            report.blocker("issue ##{issue_number} 的 Evidence status 必须为 accepted")
          end
          untested = Array(evidence["untested"])
          report.blocker("issue ##{issue_number} 仍有未实测必需项：#{untested.join("、")}") unless untested.empty?
        end
      elsif !issue.completed?
        report.blocker("issue ##{issue_number} 未以 completed 关闭")
      end

      report
    end

    # 终验复核（#124 起并入 Verifier：Reviewer 不再是独立角色，
    # 两阶段的独立性由分离进程承载，机制要求见 docs/design/process/verifier.md）。
    #
    # checker 必填：终验不允许「自报已修复」——每项 must_fix 都要由 checker
    # 重新执行检查（生产入口注入 VerifyChecks.rerun）。旧的无 checker 分支已删除。
    #
    # fixes 结构（键两种都接受，条目 id 优先）：
    #   { "must_fix-1" => {"commit" => "...", "passed" => true, "reason" => "..."},
    #     "g"         => {"commit" => "...", "passed" => true} }   # 条目自身 id
    #     "acceptable-2" => {"reason_still_valid" => true, "note" => "..."}
    def final_verification(verifier_report, fixes, checker:)
      report = VerificationReport.new
      # 注意 tally 带块时按「块的返回值」逐个计数，这里要的是每个 level 的条目数。
      level_counts = verifier_report.items.group_by(&:level).transform_values(&:length)
      reserved_ids = verifier_report.items.map(&:id)

      if verifier_report.blockers.any?
        report.blocker("Verifier 存在未解决阻断项：#{verifier_report.blockers.map(&:message).join("；")}")
      end

      verifier_report.must_fix_items.each_with_index do |item, index|
        fix = lookup(fixes, item, index + 1, level_counts, reserved_ids)
        unless fix.is_a?(Hash)
          report.blocker("应修项 #{item.id} 未修复：#{item.message}")
          next
        end

        result = checker.call(item, fix)
        if result.is_a?(Hash) && result[:passed] == true
          report.ok("应修项 #{item.id} 已收口", evidence: result[:reason])
        else
          reason = result.is_a?(Hash) ? result[:reason] : "checker 返回非法结果"
          report.blocker("应修项 #{item.id} 修复不完整：#{reason}")
        end
      end

      verifier_report.acceptable_items.each_with_index do |item, index|
        fix = lookup(fixes, item, index + 1, level_counts, reserved_ids)
        if fix.is_a?(Hash) && fix["reason_still_valid"] == true
          report.acceptable("可留项 #{item.id} 理由仍成立：#{item.message}")
        elsif fix.is_a?(Hash) && fix["reason_still_valid"] == false
          report.must_fix("可留项 #{item.id} 的理由已失效：#{fix["note"] || item.message}")
        else
          report.must_fix("可留项 #{item.id} 未复核其理由是否仍成立：#{item.message}")
        end
      end

      verifier_report.unverified_items.each do |item|
        if item.evidence.to_s.empty?
          report.blocker("未实测项 #{item.id} 无间接证据")
        else
          report.unverified("#{item.message}（间接证据：#{item.evidence}）")
        end
      end

      report
    end

    # fixes 键解析：先按条目自身 id 找，再按「同 level 内的序号」生成 fallback 键
    # （must_fix-1 …）。两条路都找不到才算未修复——不能因为键写法不同就误判。
    #
    # 三级兜底严格受限：
    #   - 条目 id 精确匹配，永远优先；
    #   - 位置键按 level 内 1-based 序号构造，不由 id 后缀推断（避免 r2-1/r3-1 撞键）；
    #     但位置键本身可能就是**另一条目**的显式 id（如首项 id=must_fix-2），
    #     这种情况下不得复用，否则一条 fix 会同时满足两项；
    #   - 纯 level 简写只在同 level 恰有一项时生效，否则一项修复会放行多项；
    #     且该键不得是任一条目的显式 id（否则与 exact-id 命中重复计一次）。
    def lookup(fixes, item, position, level_counts, reserved_ids)
      direct = fixes[item.id]
      return direct if direct.is_a?(Hash)

      positional_key = "#{item.level}-#{position}"
      positional = fixes[positional_key]
      if positional.is_a?(Hash) && !reserved_ids.include?(positional_key)
        return positional
      end

      level_key = fixes[item.level]
      return nil unless level_key.is_a?(Hash) && level_counts[item.level] == 1
      return nil if reserved_ids.include?(item.level)

      level_key
    end

    def relative(path, root)
      path.delete_prefix(File.expand_path(root)).delete_prefix(File::SEPARATOR).tr("\\", "/")
    end
  end
end
