#!/usr/bin/env ruby
# frozen_string_literal: true

# check_docs.rb 的回归测试：行号边界、review 存档、链接和退出码。
require "fileutils"
require "minitest/autorun"
require "tmpdir"
require_relative "check_docs"

class LineAnchorTest < Minitest::Test
  def anchors_in(text)
    text.scan(CheckDocs::LINE_ANCHOR).map { Regexp.last_match(0) }
  end

  def test_l_prefixed_colon
    assert_equal ["design.md:L749"], anchors_in("见 design.md:L749")
  end

  def test_l_prefixed_space
    assert_equal ["design.md L846"], anchors_in("见 design.md L846")
  end

  def test_bare_number_after_colon
    assert_equal ["design.md:473"], anchors_in("见 design.md:473")
  end

  def test_range_after_colon
    assert_equal ["design.md:341-342"], anchors_in("design.md:341-342")
  end

  def test_range_after_colon_with_l
    assert_equal ["design.md:L921-928"], anchors_in("design.md:L921-928")
  end

  def test_fullwidth_colon
    assert_equal ["design.md：749"], anchors_in("design.md：749")
  end

  def test_chapter_count_is_not_an_anchor
    assert_empty anchors_in("design.md 16 章")
  end

  def test_plain_section_reference_is_not_an_anchor
    assert_empty anchors_in("design.md §14 与 design.md §5.3")
  end

  def test_development_plan_is_covered
    assert_equal ["development-plan.md:17"], anchors_in("development-plan.md:17")
  end

  def test_unrelated_filename_is_not_covered
    assert_empty anchors_in("naming.md:12")
  end
end

class ReviewDirTest < Minitest::Test
  def anchor_level(relative_directory)
    Dir.mktmpdir do |root|
      directory = File.join(root, relative_directory)
      FileUtils.mkdir_p(directory)
      path = File.join(directory, "x.md")
      File.write(path, "见 design.md:L846\n", mode: "w", encoding: "UTF-8")
      problems = []
      CheckDocs.check_line_anchors(path, ["见 design.md:L846"], problems, root)
      return problems.map(&:first)
    end
  end

  def test_review_dir_warns
    assert_equal ["WARN"], anchor_level(File.join("docs", "design", "review"))
  end

  def test_other_dir_fails
    assert_equal ["FAIL"], anchor_level(File.join("docs", "design", "spec"))
  end
end

class CheckDocsIntegrationTest < Minitest::Test
  def test_dead_link_fails_and_valid_link_passes
    Dir.mktmpdir do |root|
      directory = File.join(root, "docs")
      FileUtils.mkdir_p(directory)
      File.write(File.join(directory, "target.md"), "OK\n")
      File.write(File.join(directory, "index.md"), "[有效](target.md) [失效](missing.md)\n")
      out = StringIO.new
      status = CheckDocs.run([], repo_root: root, out: out, err: StringIO.new)
      assert_equal 1, status
      assert_includes out.string, "FAIL"
      refute_includes out.string, "target.md）"
    end
  end

  def test_missing_root_returns_two
    status = CheckDocs.run([], repo_root: Dir.mktmpdir, out: StringIO.new, err: StringIO.new)
    assert_equal 2, status
  end
end

class DisplayWidthTest < Minitest::Test
  def test_ascii_is_one_column_each
    assert_equal 5, CheckDocs.display_width("hello")
  end

  def test_cjk_counts_two_columns
    assert_equal 8, CheckDocs.display_width("中文段落")
  end

  def test_mixed_width_and_fullwidth_punctuation
    # 「文」2 + "ok"2 + 「，」2 + 「？」2
    assert_equal 8, CheckDocs.display_width("文ok，？")
  end

  def test_western_punctuation_stays_single_column
    # 破折号与引号属西文标点区（0x2010–0x2E7F），不按宽字符算
    assert_equal 3, CheckDocs.display_width("a—b")
  end

  def test_screen_lines_folds_long_paragraph_but_not_tables_or_code
    lines = [
      "短句",                       # 段落块 6 列 → 1 屏行
      "文" * 60,                   # 同一段落的软换行，累加到 126 列 → 2 屏行
      "",                          # 空行结束段落
      "| 表格 " + ("文" * 80) + " |", # 表格行横向滚动，1 屏行
      "```",                       # 围栏 1 屏行
      "文" * 60,                   # 代码块内容 1 屏行
      "```"                        # 收尾围栏 1 屏行
    ]
    # 2 + 1 + 1 + 1 + 1 = 6
    assert_equal 6, CheckDocs.screen_lines(lines, 100)
  end

  # 逐行 ceil 再相加会系统性高估：每行的零头都被各算一整行。
  def test_screen_lines_does_not_overestimate_short_lines
    # 10 行各 51 列加 9 个分隔空格 = 519 列 → 6 屏行；逐行 ceil 会算成 10。
    lines = Array.new(10) { "文" * 25 + "a" }
    assert_equal 6, CheckDocs.screen_lines(lines, 100)
  end

  def test_screen_lines_counts_soft_break_spaces
    lines = Array.new(400) { "文" * 50 }
    assert_equal 404, CheckDocs.screen_lines(lines, 100)
  end

  def test_screen_lines_closes_heading_before_body
    lines = Array.new(200) { ["# " + ("文" * 25) + "a", "文" * 74 + "a"] }.flatten
    assert_equal 600, CheckDocs.screen_lines(lines, 100)
  end

  # 相邻列表项不能共享余量：每项各自起行。
  def test_screen_lines_counts_each_list_item_separately
    lines = Array.new(10) { "- " + "文" * 24 + "a" } # 每项 50 列
    assert_equal 10, CheckDocs.screen_lines(lines, 100)
  end

  # CommonMark 有序列表除 `1.` 外也接受 `1)`；漏认会把整段当成一个段落累加。
  def test_screen_lines_accepts_paren_ordered_list_marker
    lines = Array.new(201) { "1) " + "a" * 101 } # 每项 104 列 → 2 屏
    assert_equal 402, CheckDocs.screen_lines(lines, 100)
  end

  def test_screen_lines_accepts_dot_ordered_list_marker
    lines = Array.new(201) { "1. " + "a" * 101 }
    assert_equal 402, CheckDocs.screen_lines(lines, 100)
  end

  # `#tag` 不是 ATX 标题，应与其他普通行合并为同一段落。
  def test_screen_lines_does_not_treat_hashtag_as_heading
    lines = Array.new(201) { "#tag " + "a" * 96 }
    assert_equal 206, CheckDocs.screen_lines(lines, 100)
  end

  def test_screen_lines_does_not_treat_seven_hashes_as_heading
    lines = Array.new(201) { "####### " + "a" * 91 } # 每行 99 列，含 200 个软换行空格
    assert_equal 201, CheckDocs.screen_lines(lines, 100)
  end

  def test_screen_lines_treats_real_headings_as_blocks
    lines = Array.new(100) { ["# 标题", "正文"] }.flatten
    assert_equal 200, CheckDocs.screen_lines(lines, 100)
  end

  def test_screen_lines_treats_atx_heading_without_text_as_block
    lines = ["##", "正文"]
    assert_equal 2, CheckDocs.screen_lines(lines, 100)
  end

  def test_long_lines_skips_code_blocks_and_tables
    lines = ["```", "文" * 300, "```", "| " + ("文" * 300) + " |"]
    assert_empty CheckDocs.long_lines(lines, 400)
  end

  def test_long_lines_reports_paragraphs_and_list_items
    lines = ["文" * 201, "- " + ("文" * 200)]
    assert_equal [[1, 402], [2, 2 + 400]], CheckDocs.long_lines(lines, 400)
  end

  def test_fence_closes_only_with_same_marker_and_sufficient_length
    lines = [
      "````ruby",
      "```",       # 四反引号块内的三反引号不是闭栏
      "文" * 201,
      "~~~~",       # 字符不同，也不是闭栏
      "```` trailing", # 带尾随文本，仍不是闭栏
      "````",
      "文" * 201
    ]
    assert_equal [[7, 402]], CheckDocs.long_lines(lines, 400)
    # 前六行代码各占一屏；末行长段落折为五屏。
    assert_equal 11, CheckDocs.screen_lines(lines, 100)
  end

  def test_longer_closing_fence_is_allowed
    lines = ["~~~", "文" * 201, "~~~~", "文" * 201]
    assert_equal [[4, 402]], CheckDocs.long_lines(lines, 400)
  end

  def test_backtick_info_string_cannot_contain_backtick
    assert_nil CheckDocs.opening_fence("```ruby `x`")
  end

  def test_fence_must_start_within_three_spaces
    assert_nil CheckDocs.opening_fence("    ```")
  end
end

class SizeCheckTest < Minitest::Test
  OPTIONS = {max_lines: 4, display_columns: 10, max_line_columns: 20, exclude: []}.freeze

  def problems_for(text, options = OPTIONS)
    problems = []
    CheckDocs.check_size("doc.md", CheckDocs.read_lines(path_with(text)), problems, options)
    problems
  end

  def path_with(text)
    @dir ||= Dir.mktmpdir
    path = File.join(@dir, "doc.md")
    File.write(path, text, mode: "w", encoding: "UTF-8")
    path
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir
  end

  def test_physical_line_limit_warns
    assert_includes problems_for("a\nb\nc\nd\ne\n").first.last, "体量 5 行"
  end

  # 旧实现用 split("\n", -1)，末尾换行会多算一行，导致 400 行的文件也告警。
  # 现在与 File.readlines / verify docs 口径一致：400 行通过，401 行告警。
  def test_physical_line_boundary_matches_readlines
    options = {max_lines: 400, display_columns: 0, max_line_columns: 0, exclude: []}
    ok = (["填充"] * 400).join("\n") + "\n"
    over = (["填充"] * 401).join("\n") + "\n"
    assert_equal 400, CheckDocs.read_lines(path_with(ok)).length
    assert_empty problems_for(ok, options).select { |p| p.last.include?("体量") }
    messages = problems_for(over, options).map(&:last)
    assert messages.any? { |m| m.include?("体量 401 行") }, messages.inspect
  end

  def test_equivalent_screen_lines_catch_long_paragraph
    # 2 个物理行，折算后 3+3+3 → 远超 4 行阈值
    messages = problems_for(("文" * 20 + "\n") * 3).map(&:last)
    assert messages.any? { |m| m.include?("等效屏幕行") }, messages.inspect
  end

  def test_long_single_line_warns_with_width
    messages = problems_for("短\n" + ("文" * 15) + "\n").map(&:last)
    assert messages.any? { |m| m.include?("显示宽度 > 20 列") }, messages.inspect
  end

  # 超宽表格行不报长行：宽度由列内容决定，收窄只能删信息。
  # 但它仍然算一屏行，所以表格的体量由等效屏幕行覆盖。
  def test_tables_skipped_by_long_line_check
    table = "| " + ("文" * 20) + " |\n"
    messages = problems_for(table).map(&:last)
    refute messages.any? { |m| m.include?("等效屏幕行") }, messages.inspect
    refute messages.any? { |m| m.include?("显示宽度") }, messages.inspect
  end

  def test_code_block_skipped_by_long_line_check
    messages = problems_for("```\n" + ("文" * 40) + "\n```\n").map(&:last)
    refute messages.any? { |m| m.include?("显示宽度") }, messages.inspect
  end

  def test_checks_can_be_disabled
    off = OPTIONS.merge(display_columns: 0, max_line_columns: 0, max_lines: 100)
    assert_empty problems_for("文" * 500, off)
  end

  def test_zero_max_lines_means_unlimited
    off = OPTIONS.merge(max_lines: 0)
    assert_empty problems_for(("文" * 2 + "\n") * 10, off)
  end

  # 存档是历史快照：新增的两项长行检查跳过 docs/design/review/，
  # 但物理行超限仍照旧检查。research/ 可维护，不在豁免内。
  def test_archive_dir_skips_long_line_checks_but_not_line_limit
    dir = File.join(archives_root, "docs/design/review")
    path = File.join(dir, "review.md")

    File.write(path, "文" * 300 + "\n", mode: "w", encoding: "UTF-8")
    problems = []
    CheckDocs.check_size(path, CheckDocs.read_lines(path), problems, OPTIONS, repo_root: archives_root)
    assert_empty problems, problems.inspect

    File.write(path, (["填充"] * 5).join("\n") + "\n", mode: "w", encoding: "UTF-8")
    problems = []
    CheckDocs.check_size(path, CheckDocs.read_lines(path), problems, OPTIONS, repo_root: archives_root)
    assert problems.any? { |p| p.last.include?("体量 5 行") }, problems.inspect
  end

  def test_research_dir_is_not_exempt
    dir = File.join(archives_root, "docs/design/research")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "r.md")
    File.write(path, "文" * 300 + "\n", mode: "w", encoding: "UTF-8")
    problems = []
    CheckDocs.check_size(path, CheckDocs.read_lines(path), problems, OPTIONS, repo_root: archives_root)
    assert problems.any? { |p| p.last.include?("显示宽度") }, problems.inspect
  end

  def archives_root
    @archives_root ||= begin
      root = Dir.mktmpdir
      FileUtils.mkdir_p(File.join(root, "docs/design/review"))
      root
    end
  end
end

class SizeCheckCliTest < Minitest::Test
  def with_docs(text, argv = [])
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "docs"))
      File.write(File.join(root, "docs", "x.md"), text, mode: "w", encoding: "UTF-8")
      out = StringIO.new
      status = CheckDocs.run(argv, repo_root: root, out: out, err: StringIO.new)
      return [status, out.string]
    end
  end

  # WARN 不阻断：长行只告警，退出码仍为 0，否则 CI 会被存量长行卡死。
  def test_long_line_warns_without_failing
    status, output = with_docs("文" * 300)
    assert_equal 0, status
    assert_includes output, "显示宽度 > 400 列"
    assert_includes output, "WARN 1"
  end

  def test_cli_flags_change_thresholds
    status, output = with_docs("文" * 300, ["--max-line-columns", "700"])
    assert_equal 0, status
    refute_includes output, "显示宽度"
  end

  def test_cli_flags_can_disable_display_checks
    status, output = with_docs("文" * 300, ["--display-columns", "0", "--max-line-columns", "0"])
    assert_equal 0, status
    refute_includes output, "显示宽度"
    assert_includes output, "WARN 0"
  end
end