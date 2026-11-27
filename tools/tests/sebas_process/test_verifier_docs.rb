# frozen_string_literal: true

# Verifier 的文档核验：行号锚、体量、可复跑 evidence 命令、存档豁免。

require_relative "../support/boot"
require_relative "../../agents/lib/sebas_agents"

class VerifierDocsTest < Minitest::Test
  include SnapshotHelpers

  def test_docs_reports_line_anchors_and_size
    Dir.mktmpdir do |dir|
      path = File.join(dir, "doc.md")
      File.write(path, "见 design.md:L12\n" + ("填充\n" * 410), encoding: "UTF-8")
      report = SebasAgents::Verifier.verify_docs(["doc.md"], root: dir, max_lines: 400)
      refute report.pass?
      assert report.must_fix_items.any? { |item| item.message.include?("行号锚") }
      assert report.must_fix_items.any? { |item| item.message.include?("超过") }
    end
  end

  # #124：可复跑的 must_fix 必须带 evidence 命令，checker 才能就地复跑收口。
  def test_docs_must_fix_items_carry_rerunnable_evidence
    Dir.mktmpdir do |dir|
      path = File.join(dir, "doc.md")
      File.write(path, "见 design.md:L12\n" + ("填充\n" * 410), encoding: "UTF-8")
      report = SebasAgents::Verifier.verify_docs(["doc.md"], root: dir, max_lines: 400)

      size_item = report.must_fix_items.find { |item| item.message.include?("超过") }
      refute_nil size_item&.evidence, "行数超限条目应带可复跑命令"
      require "shellwords"
      assert_equal SebasAgents::Verifier::RERUN_LINE_COUNT % [400, Shellwords.escape("doc.md")], size_item.evidence

      anchor_item = report.must_fix_items.find { |item| item.message.include?("行号锚") }
      refute_nil anchor_item&.evidence, "锚点存在条目应带可复跑命令"
      assert_equal SebasAgents::Verifier::RERUN_DOCS_CHECK % Shellwords.escape("doc.md"), anchor_item.evidence

      # 行数命令真实复跑：修复后（行数降回上限内）应通过。
      checker = SebasAgents::VerifyChecks
      File.write(path, "见 design.md\n", encoding: "UTF-8")
      shrunk = SebasAgents::Verifier.verify_docs(["doc.md"], root: dir, max_lines: 400)
      assert shrunk.pass?, "行数修复后应无 must_fix"
      result = checker.rerun(size_item, {}, root: dir)
      assert result[:passed], "行数 evidence 命令对修复后的文件应通过：#{result[:reason]}"
    end
  end

  # CodeRabbit：路径含空格时必须整体作为一个参数被 checker 解析。
  def test_rerun_command_escapes_paths_with_spaces
    Dir.mktmpdir do |dir|
      tricky = File.join(dir, "guide notes.md")
      File.write(tricky, "填充\n" * 401, encoding: "UTF-8")
      report = SebasAgents::Verifier.verify_docs(["guide notes.md"], root: dir, max_lines: 400)
      item = report.must_fix_items.find { |i| i.message.include?("超过") }
      refute_nil item&.evidence
      require "shellwords"
      assert_includes item.evidence, Shellwords.escape("guide notes.md")

      # 同时放一个更短的同前缀文件：不转义时命令会读错对象并误判通过。
      File.write(File.join(dir, "guide"), "一行\n", encoding: "UTF-8")
      result = SebasAgents::VerifyChecks.rerun(item, {}, root: dir)
      refute result[:passed], "含空格路径必须整体复跑且仍失败：#{result[:reason]}"
    end
  end

  # 存档目录的行号锚是 acceptable，不参与终验，不带 evidence。
  def test_archive_anchor_item_has_no_evidence
    Dir.mktmpdir do |dir|
      path = File.join(dir, "docs/design/review/x.md")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "见 design.md:L12\n", encoding: "UTF-8")
      report = SebasAgents::Verifier.verify_docs(["docs/design/review/x.md"], root: dir)
      assert report.acceptable_items.first.evidence.nil?
    end
  end

  def test_archive_line_anchor_is_acceptable
    Dir.mktmpdir do |dir|
      path = File.join(dir, "docs/design/review/x.md")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "见 design.md:L12\n", encoding: "UTF-8")
      report = SebasAgents::Verifier.verify_docs(["docs/design/review/x.md"], root: dir)
      assert report.pass?
      assert_equal 1, report.acceptable_items.length
    end
  end

  def test_missing_file_blocks
    Dir.mktmpdir do |dir|
      report = SebasAgents::Verifier.verify_docs(["missing.md"], root: dir)
      assert_equal 1, report.blockers.length
    end
  end

  def test_code_anchor_mismatch
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "src", "x.cr"), "真实内容\n", encoding: "UTF-8")
      report = SebasAgents::Verifier.verify_code_anchors(
        [{"file" => "src/x.cr", "line" => 1, "content" => "文档声称"}], root: dir
      )
      assert_equal 1, report.must_fix_items.length
    end
  end

  # checks 未取（nil）不能被当成「没有失败检查」：合并后核验留 unverified，
  # 合并前自检直接 blocker——否则两段式会让门禁静默失效。
  def test_verify_merge_without_loaded_checks_is_not_silent
    data = snapshot(
      issues: [issue(39, body: automation, state: "CLOSED", state_reason: "COMPLETED")],
      pull_requests: [{"number" => 10, "state" => "MERGED", "closing_issues" => [39]}]
    )
    report = SebasAgents::Verifier.verify_merge(10, 39, SebasAgents::Model::Snapshot.from_hash(data))
    assert(report.unverified_items.any? { |i| i.message.include?("CI 检查未随快照取回") },
      report.items.map(&:message).inspect)
    assert_equal "有条件通过", report.conclusion
  end

  def test_verify_merge_requires_completed_issue
    data = snapshot(
      issues: [issue(39, body: automation, state: "CLOSED", state_reason: "NOT_PLANNED")],
      pull_requests: [{"number" => 10, "state" => "MERGED", "closing_issues" => [39]}]
    )
    report = SebasAgents::Verifier.verify_merge(10, 39, SebasAgents::Model::Snapshot.from_hash(data))
    refute report.pass?
  end
end
