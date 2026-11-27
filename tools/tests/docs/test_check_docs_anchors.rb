# frozen_string_literal: true

# check_docs 的锚点与链接回归：行号锚形态、review 存档降级、死链退出码。

require_relative "../support/boot"
require_relative "../../check_docs"

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
