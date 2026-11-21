# frozen_string_literal: true

require "json"
require "open3"

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
          report.must_fix("#{relative_path} 共 #{line_count} 行，超过 #{max_lines} 行上限")
        end

        anchors = text.scan(LINE_ANCHOR).map { |match| match.join }
        next if anchors.empty?

        level = ARCHIVE_DIRS.any? { |dir| relative_path.start_with?(dir) } ? :acceptable : :must_fix
        anchors.tally.each do |anchor, count|
          report.public_send(level, "#{relative_path} 含行号锚 #{anchor.inspect}（#{count} 处）")
        end
      end
      report
    end

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
    #            只核验可提前判定的项——关联 issue、CI 全绿、无未完成检查。
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
        report.must_fix("PR ##{pr_number} 仍有未完成的检查")
      end
      if expected_head && pr.head_sha != expected_head
        report.must_fix("PR ##{pr_number} head #{pr.head_sha} 与记录的 #{expected_head} 不符")
      end

      issue = snapshot.issue(issue_number)
      if issue.nil?
        report.blocker("issue ##{issue_number} 不在快照内")
      elsif pre
        report.blocker("issue ##{issue_number} 已关闭，不能再作为合并前自检对象") unless issue.open?
      elsif !issue.completed?
        report.blocker("issue ##{issue_number} 未以 completed 关闭")
      end

      report
    end

    def relative(path, root)
      path.delete_prefix(File.expand_path(root)).delete_prefix(File::SEPARATOR).tr("\\", "/")
    end
  end
end
