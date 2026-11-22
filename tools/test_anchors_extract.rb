# frozen_string_literal: true

# anchors_extract 单测（#121）。全部基于 tmpdir，不触网。
require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "anchors_extract"

class AnchorsExtractTest < Minitest::Test
  def with_repo
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      FileUtils.mkdir_p(File.join(dir, "docs"))
      yield dir
    end
  end

  def write(root, relative, content)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content, encoding: "UTF-8")
  end

  # --- 抽取 ---

  def test_extracts_single_reference
    with_repo do |dir|
      write(dir, "src/x.cr", "第一行\n目标行\n第三行\n")
      write(dir, "docs/a.md", "见 src/x.cr:2 的实现。\n")

      anchors, skipped, problems = AnchorExtractor.extract(["docs/a.md"], root: dir)
      assert_empty problems
      assert_empty skipped
      assert_equal 1, anchors.length
      assert_equal "src/x.cr", anchors[0]["file"]
      assert_equal 2, anchors[0]["line"]
      assert_equal "目标行", anchors[0]["content"]
    end
  end

  def test_extracts_range_endpoints
    with_repo do |dir|
      write(dir, "src/x.cr", (1..20).map { |i| "行#{i}\n" }.join)
      write(dir, "docs/a.md", "见 src/x.cr:3-6 的区间。\n")

      anchors, = AnchorExtractor.extract(["docs/a.md"], root: dir)
      # 只核验端点，不逐行展开：区间表达「这一带」。
      assert_equal [3, 6], anchors.map { |anchor| anchor["line"] }.sort
    end
  end

  def test_extracts_comma_separated
    with_repo do |dir|
      write(dir, "src/x.cr", (1..30).map { |i| "行#{i}\n" }.join)
      write(dir, "docs/a.md", "见 src/x.cr:5,8-10。\n")

      anchors, = AnchorExtractor.extract(["docs/a.md"], root: dir)
      assert_equal [5, 8, 10], anchors.map { |anchor| anchor["line"] }.sort
    end
  end

  # 外部项目引用（如研究笔记引用 autobot 仓库）不得判错，否则引入假红。
  def test_skips_paths_not_in_repo
    with_repo do |dir|
      write(dir, "docs/a.md", "参考 src/autobot/cli/gateway.cr:76 的设计。\n")

      anchors, skipped, problems = AnchorExtractor.extract(["docs/a.md"], root: dir)
      assert_empty anchors
      assert_empty problems, "外部路径不得判错"
      assert_equal 1, skipped.length
      assert_includes skipped[0]["ref"], "src/autobot/cli/gateway.cr:76"
    end
  end

  # 指向空行：无法逐字比对，也不是漂移信号，记 skipped。
  def test_skips_blank_line_targets
    with_repo do |dir|
      write(dir, "src/x.cr", "第一行\n\n第三行\n")
      write(dir, "docs/a.md", "见 src/x.cr:2。\n")

      anchors, skipped, problems = AnchorExtractor.extract(["docs/a.md"], root: dir)
      assert_empty anchors
      assert_empty problems
      assert_equal "指向空行", skipped[0]["reason"]
    end
  end

  def test_reports_out_of_range_as_problem
    with_repo do |dir|
      write(dir, "src/x.cr", "只有一行\n")
      write(dir, "docs/a.md", "见 src/x.cr:999。\n")

      anchors, _skipped, problems = AnchorExtractor.extract(["docs/a.md"], root: dir)
      assert_empty anchors
      assert_equal 1, problems.length
      assert_includes problems[0], "只有 1 行"
    end
  end

  def test_ignores_non_tracked_prefixes
    with_repo do |dir|
      write(dir, "docs/a.md", "版本 1.2:3 与 foo/bar.cr:1 都不该被抽取。\n")

      anchors, skipped, problems = AnchorExtractor.extract(["docs/a.md"], root: dir)
      assert_empty anchors
      assert_empty skipped
      assert_empty problems
    end
  end

  def test_dedupe_keeps_one_per_file_line
    with_repo do |dir|
      write(dir, "src/x.cr", "一行\n二行\n")
      write(dir, "docs/a.md", "见 src/x.cr:1 与 src/x.cr:1 重复。\n")

      anchors, = AnchorExtractor.extract(["docs/a.md"], root: dir)
      assert_equal 2, anchors.length
      assert_equal 1, AnchorExtractor.dedupe(anchors).length
    end
  end

  # --- run 层 ---

  def test_run_writes_output_file
    with_repo do |dir|
      write(dir, "src/x.cr", "内容\n")
      write(dir, "docs/a.md", "见 src/x.cr:1。\n")
      out_path = File.join(dir, "anchors.json")

      code = AnchorExtractor.run(
        ["--output", out_path, "docs/a.md"], root: dir,
        out: StringIO.new, err: StringIO.new
      )
      assert_equal 0, code
      data = JSON.parse(File.read(out_path, encoding: "UTF-8"))
      assert_equal 1, data.length
      assert_equal "内容", data[0]["content"]
    end
  end

  def test_run_refuses_when_out_of_range
    with_repo do |dir|
      write(dir, "src/x.cr", "一行\n")
      write(dir, "docs/a.md", "见 src/x.cr:50。\n")
      err = StringIO.new

      code = AnchorExtractor.run(["docs/a.md"], root: dir, out: StringIO.new, err: err)
      assert_equal 1, code, "越界必须 fail-closed"
      assert_includes err.string, "行号越界"
    end
  end

  def test_run_requires_paths
    err = StringIO.new
    code = AnchorExtractor.run([], root: Dir.pwd, out: StringIO.new, err: err)
    assert_equal 2, code
    assert_includes err.string, "至少需要一个"
  end
end
